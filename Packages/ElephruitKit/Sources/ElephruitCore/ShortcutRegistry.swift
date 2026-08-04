import Foundation

/// Which modifier keys a shortcut needs.
///
/// Its own type rather than SwiftUI's `EventModifiers` because this lives in `ElephruitCore`, which
/// has no framework above Foundation — that is what lets the whole registry be tested without a
/// window, and what lets the same binding drive a menu item, a palette row, and a Carbon
/// registration without three descriptions of it.
public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)

    /// In the order macOS writes them in a menu: ⌃⌥⇧⌘.
    public var glyphs: [String] {
        var out: [String] = []
        if contains(.control) { out.append("⌃") }
        if contains(.option) { out.append("⌥") }
        if contains(.shift) { out.append("⇧") }
        if contains(.command) { out.append("⌘") }
        return out
    }
}

/// One key plus its modifiers.
public struct KeyBinding: Sendable, Hashable, Codable {
    /// A single character, lowercased. Uppercase is expressed with `.shift`, not by the letter.
    public let key: String
    public let modifiers: KeyModifiers

    public init(_ key: String, _ modifiers: KeyModifiers = .command) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// What a menu or a palette row shows — `["⌘", "⇧", "N"]`.
    public var glyphs: [String] {
        modifiers.glyphs + [key.uppercased()]
    }

    public var display: String { glyphs.joined() }
}

/// Everything the app can be asked to do by keyboard.
///
/// One case per command, so a binding has exactly one owner. Before this, forty
/// `.keyboardShortcut` literals were scattered across the app and the palette carried a *second*,
/// cosmetic description of some of them as `["⌘","⇧","N"]` glyph arrays — two representations of
/// the same fact, with nothing keeping them equal. A palette that lies about a shortcut is worse
/// than one that shows none.
public enum ShortcutCommand: String, CaseIterable, Sendable, Codable {
    case newItem
    case newReminder = "newTask"
    case newProject
    case quickCapture
    case newWindow
    case importFiles
    case exportLibrary
    case moveToTrash
    case search
    case commandPalette
    case goToday
    case goInbox
    case goNotes
    case goProjects
    case goRecords = "goPeople"
    case toggleSidebar
    case toggleInspectorAlternate
    case focusMode
    case clearSelection
    case toggleTimer
    case quickLog
    case recordsCommandBar = "peopleCommandBar"
    case quickReminderEntry = "quickTaskEntry"
    case goReminders = "goTasks"
    case completeReminder = "completeTask"
    case flagReminder = "flagTask"
    case moveToToday

    // MARK: The calendar
    case goCalendar
    case newEvent
    case searchCalendar
    case switchCalendarSet

    // MARK: The window
    case goBack
    case goForward
    case collapseToTimer

    public var title: String {
        switch self {
        case .newItem: "New Item"
        case .newReminder: "New Reminder"
        case .newProject: "New Project"
        case .quickCapture: "Quick Jot"
        case .newWindow: "New Window"
        case .importFiles: "Import Files…"
        case .exportLibrary: "Export Library…"
        case .moveToTrash: "Move to Trash"
        case .search: "Search Everything"
        case .commandPalette: "Command Palette"
        case .goToday: "Go to Today"
        case .goInbox: "Go to Inbox"
        case .goNotes: "Go to Notes"
        case .goProjects: "Go to Projects"
        case .goRecords: "Go to Records"
        case .toggleSidebar: "Toggle Sidebar"
        case .toggleInspectorAlternate: "Toggle Inspector"
        case .focusMode: "Focus Mode"
        case .clearSelection: "Clear Selection"
        case .toggleTimer: "Start or Stop Timer"
        case .quickLog: "Quick Log"
        case .recordsCommandBar: "Records Command Bar"
        case .goCalendar: "Go to Calendar"
        case .newEvent: "New Event"
        case .searchCalendar: "Search Calendar"
        case .switchCalendarSet: "Switch Calendar Set"
        case .quickReminderEntry: "Quick Reminder Entry"
        case .goReminders: "Go to Reminders"
        case .completeReminder: "Complete Reminder"
        case .flagReminder: "Flag Reminder"
        case .moveToToday: "Move to Today"
        case .goBack: "Back"
        case .goForward: "Forward"
        case .collapseToTimer: "Collapse to Timer"
        }
    }

    /// What ships bound, matching what the app already used.
    public var defaultBinding: KeyBinding {
        switch self {
        case .newItem: KeyBinding("n")
        case .newReminder: KeyBinding("n", [.command, .option])
        case .newProject: KeyBinding("n", [.command, .shift, .option])
        // ⌘⇧J for Jot. It used to be ⌘⇧N, which put it in the middle of the four New-something
        // bindings — ⌘N, ⌥⌘N, ⌥⇧⌘N, ⌃⌘N — where the only thing distinguishing the one global,
        // works-from-any-app shortcut from its neighbours was which modifiers you happened to be
        // holding. The initial of its own name is both easier to remember and further from
        // anything else, which is what a shortcut you press from inside another application needs.
        case .quickCapture: KeyBinding("j", [.command, .shift])
        case .newWindow: KeyBinding("n", [.command, .control])
        // ⌘⇧I, which is the binding this command already had — under the name "Show Inspector",
        // which is not what it does. The registry exists so that a shortcut has exactly one owner and
        // that owner's name is true; a menu item borrowing another command's identity defeats both,
        // and made the shortcut editor in Settings offer to rebind the inspector and rebind importing.
        case .importFiles: KeyBinding("i", [.command, .shift])

        case .exportLibrary: KeyBinding("e", [.command, .shift, .option])
        case .moveToTrash: KeyBinding("\u{8}", .command)
        case .search: KeyBinding("f")
        case .commandPalette: KeyBinding("k")
        case .goToday: KeyBinding("0")
        case .goInbox: KeyBinding("1")
        // ⌘2 is deliberately unbound. It belonged to Upcoming, which is now part of Today, and the
        // three bindings below are not a numbered list of sidebar rows — they are stable bindings
        // for three modules. Sliding them up to close a gap would relearn three shortcuts to tidy
        // one, which is a worse trade than a free key.
        case .goNotes: KeyBinding("3")
        case .goProjects: KeyBinding("4")
        case .goRecords: KeyBinding("5")
        case .toggleSidebar: KeyBinding("s", [.command, .control])
        case .toggleInspectorAlternate: KeyBinding("i", [.command, .option])
        case .focusMode: KeyBinding("f", [.command, .option])
        case .clearSelection: KeyBinding("l", .command)
        case .toggleTimer: KeyBinding("t", [.command, .control])
        // ⌘⇧L for Log, on exactly the reasoning that moved Quick Jot to ⌘⇧J: a shortcut pressed from
        // inside another application has to be remembered without the app in front of you, and the
        // initial of its own name is the only mnemonic that survives that. It sits beside ⌘⇧J
        // deliberately — the two are the same gesture aimed at the two things this app is for, a
        // thought and an hour — and it is nowhere near ⌃⌘T, which starts a timer against whatever is
        // selected *inside* the app and is a different question with a different answer.
        //
        // ⌘L on its own belongs to Focus Sidebar, and shift is what separates them. Nothing else in
        // the registry wants these keys; `ShortcutRegistryTests` fails if that ever stops being true.
        case .quickLog: KeyBinding("l", [.command, .shift])
        // ⌘⇧K, beside ⌘K for the general palette: the two are siblings, and the shift says "the one
        // about people". Every binding still has exactly one owner — `ShortcutRegistryTests` proves
        // it over `allCases`, so a collision introduced here fails a test rather than silently
        // shadowing the palette.
        case .recordsCommandBar: KeyBinding("k", [.command, .shift])

        // ⌘6, continuing the numeric run that already reaches People at ⌘5.
        case .goCalendar: KeyBinding("6")
        // ⌘⇧E for an event: memorable, reachable, and global. Export moves to ⌥⇧⌘E so the action
        // somebody uses throughout the day owns the simpler binding.
        case .newEvent: KeyBinding("e", [.command, .shift])
        // ⌥⌘E — beside ⇧⌘E, which creates an event, so the two calendar verbs share a letter and
        // differ by modifier. This was ⌃⌘F, which is the *system's* Enter Full Screen binding,
        // present in the View menu of every application: a default that shadows a system-wide key
        // is a default that was never pressable.
        case .searchCalendar: KeyBinding("e", [.command, .option])
        case .switchCalendarSet: KeyBinding("s", [.command, .option])

        // Preserve the historical raw values so existing shortcut preferences keep working.
        //
        // ⌃⌘R — R for reminder. This was ⌃⌘Space, which macOS owns for Emoji & Symbols on every
        // text field in every application; a binding the system takes first is one this registry
        // only appeared to own.
        case .quickReminderEntry: KeyBinding("r", [.command, .control])
        case .goReminders: KeyBinding("7")
        // Return-adjacent, because completing is what you do most and ⌘Return is free here: the
        // lists are not text fields, and the text fields that exist handle their own Return.
        case .completeReminder: KeyBinding("\r", .command)
        case .flagReminder: KeyBinding("f", [.command, .shift])
        case .moveToToday: KeyBinding("t", [.command, .shift])

        // In the registry rather than hard-coded in the View menu, so the collision test covers
        // them and the Settings editor can offer them. The keys are the ones the menu always
        // claimed.
        case .goBack: KeyBinding("[", .command)
        case .goForward: KeyBinding("]", .command)
        case .collapseToTimer: KeyBinding("m", [.command, .control])
        }
    }
}

/// Where a shortcut is heard.
public enum ShortcutScope: String, Sendable, Codable {
    /// Only while Elephruit is frontmost. Delivered by the menu system.
    case application
    /// From any application. Registered with the system; see ADR 0008.
    case global
}

/// Two commands wanting the same keys.
public struct ShortcutCollision: Sendable, Hashable {
    public let binding: KeyBinding
    public let commands: [ShortcutCommand]

    public var explanation: String {
        let names = commands.map(\.title).sorted().joined(separator: " and ")
        return "\(binding.display) is assigned to both \(names)."
    }
}

/// The one place a keyboard shortcut is decided.
///
/// Holds the defaults, applies the user's overrides on top, and can say when two commands have
/// ended up wanting the same keys. Deliberately a value type over a plain dictionary: a registry
/// that reads `UserDefaults` on every lookup would be untestable and would make a menu rebuild an
/// I/O operation.
public struct ShortcutRegistry: Sendable, Hashable {
    /// User overrides. A command absent here uses its default; a command mapped to `nil` has been
    /// deliberately unbound, which is different from never having been touched.
    public private(set) var overrides: [ShortcutCommand: KeyBinding?]

    public init(overrides: [ShortcutCommand: KeyBinding?] = [:]) {
        self.overrides = overrides
    }

    /// The binding in force, or `nil` if the command has been unbound.
    public func binding(for command: ShortcutCommand) -> KeyBinding? {
        if let override = overrides[command] { return override }
        return command.defaultBinding
    }

    public mutating func setBinding(_ binding: KeyBinding?, for command: ShortcutCommand) {
        if binding == command.defaultBinding {
            overrides.removeValue(forKey: command)
        } else {
            overrides[command] = binding
        }
    }

    public mutating func reset(_ command: ShortcutCommand) {
        overrides.removeValue(forKey: command)
    }

    public mutating func resetAll() {
        overrides.removeAll()
    }

    /// Every binding wanted by more than one command.
    ///
    /// Reported rather than prevented. Refusing the assignment would mean the user cannot swap two
    /// shortcuts without an intermediate state, and silently dropping one would be worse than
    /// either — so both stay, and the conflict is something they can see.
    public var collisions: [ShortcutCollision] {
        var byBinding: [KeyBinding: [ShortcutCommand]] = [:]
        for command in ShortcutCommand.allCases {
            guard let binding = binding(for: command) else { continue }
            byBinding[binding, default: []].append(command)
        }

        return byBinding
            .filter { $0.value.count > 1 }
            .map { ShortcutCollision(binding: $0.key, commands: $0.value.sorted { $0.rawValue < $1.rawValue }) }
            .sorted { $0.binding.display < $1.binding.display }
    }

    /// Which command owns these keys, if exactly one does.
    public func command(for binding: KeyBinding) -> ShortcutCommand? {
        let owners = ShortcutCommand.allCases.filter { self.binding(for: $0) == binding }
        return owners.count == 1 ? owners.first : nil
    }

    // MARK: - Persistence

    private static let storageKey = "shortcuts.overrides"

    /// Reads overrides from a defaults store.
    ///
    /// Unreadable stored data is ignored rather than thrown: a corrupt preference should cost the
    /// user their customisations, not their ability to launch.
    public static func load(from defaults: UserDefaults) -> ShortcutRegistry {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: KeyBinding?].self, from: data)
        else { return ShortcutRegistry() }

        var overrides: [ShortcutCommand: KeyBinding?] = [:]
        for (rawValue, binding) in decoded {
            guard let command = ShortcutCommand(rawValue: rawValue) else { continue }
            overrides[command] = binding
        }
        return ShortcutRegistry(overrides: overrides)
    }

    public func save(to defaults: UserDefaults) {
        guard !overrides.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        let encodable = Dictionary(
            uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }
        )
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
