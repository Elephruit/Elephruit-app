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
    case newTask
    case newProject
    case quickCapture
    case newWindow
    case toggleInspector
    case exportLibrary
    case moveToTrash
    case search
    case commandPalette
    case goToday
    case goInbox
    case goUpcoming
    case goNotes
    case goProjects
    case goPeople
    case toggleSidebar
    case toggleInspectorAlternate
    case focusMode
    case clearSelection
    case toggleTimer
    case peopleCommandBar
    case quickTaskEntry
    case goTasks
    case completeTask
    case flagTask
    case moveToToday

    // MARK: The calendar
    case goCalendar
    case newEvent
    case searchCalendar
    case switchCalendarSet

    public var title: String {
        switch self {
        case .newItem: "New Item"
        case .newTask: "New Task"
        case .newProject: "New Project"
        case .quickCapture: "Quick Jot"
        case .newWindow: "New Window"
        case .toggleInspector: "Show Inspector"
        case .exportLibrary: "Export Library…"
        case .moveToTrash: "Move to Trash"
        case .search: "Search Everything"
        case .commandPalette: "Command Palette"
        case .goToday: "Go to Today"
        case .goInbox: "Go to Inbox"
        case .goUpcoming: "Go to Upcoming"
        case .goNotes: "Go to Notes"
        case .goProjects: "Go to Projects"
        case .goPeople: "Go to People"
        case .toggleSidebar: "Toggle Sidebar"
        case .toggleInspectorAlternate: "Toggle Inspector"
        case .focusMode: "Focus Mode"
        case .clearSelection: "Clear Selection"
        case .toggleTimer: "Start or Stop Timer"
        case .peopleCommandBar: "People Command Bar"
        case .goCalendar: "Go to Calendar"
        case .newEvent: "New Event"
        case .searchCalendar: "Search Calendar"
        case .switchCalendarSet: "Switch Calendar Set"
        case .quickTaskEntry: "Quick Task Entry"
        case .goTasks: "Go to Today's Tasks"
        case .completeTask: "Complete Task"
        case .flagTask: "Flag Task"
        case .moveToToday: "Move to Today"
        }
    }

    /// What ships bound, matching what the app already used.
    public var defaultBinding: KeyBinding {
        switch self {
        case .newItem: KeyBinding("n")
        case .newTask: KeyBinding("n", [.command, .option])
        case .newProject: KeyBinding("n", [.command, .shift, .option])
        // ⌘⇧J for Jot. It used to be ⌘⇧N, which put it in the middle of the four New-something
        // bindings — ⌘N, ⌥⌘N, ⌥⇧⌘N, ⌃⌘N — where the only thing distinguishing the one global,
        // works-from-any-app shortcut from its neighbours was which modifiers you happened to be
        // holding. The initial of its own name is both easier to remember and further from
        // anything else, which is what a shortcut you press from inside another application needs.
        case .quickCapture: KeyBinding("j", [.command, .shift])
        case .newWindow: KeyBinding("n", [.command, .control])
        case .toggleInspector: KeyBinding("i", [.command, .shift])
        case .exportLibrary: KeyBinding("e", [.command, .shift])
        case .moveToTrash: KeyBinding("\u{8}", .command)
        case .search: KeyBinding("f")
        case .commandPalette: KeyBinding("k")
        case .goToday: KeyBinding("0")
        case .goInbox: KeyBinding("1")
        case .goUpcoming: KeyBinding("2")
        case .goNotes: KeyBinding("3")
        case .goProjects: KeyBinding("4")
        case .goPeople: KeyBinding("5")
        case .toggleSidebar: KeyBinding("s", [.command, .control])
        case .toggleInspectorAlternate: KeyBinding("i", [.command, .option])
        case .focusMode: KeyBinding("f", [.command, .option])
        case .clearSelection: KeyBinding("l", .command)
        case .toggleTimer: KeyBinding("t", [.command, .control])
        // ⌘⇧K, beside ⌘K for the general palette: the two are siblings, and the shift says "the one
        // about people". Every binding still has exactly one owner — `ShortcutRegistryTests` proves
        // it over `allCases`, so a collision introduced here fails a test rather than silently
        // shadowing the palette.
        case .peopleCommandBar: KeyBinding("k", [.command, .shift])

        // ⌘6, continuing the numeric run that already reaches People at ⌘5.
        case .goCalendar: KeyBinding("6")
        // ⌃⌘E for an event, ⌃⌘F for finding one. Both keep the calendar on the control layer, and
        // both were checked against every other default rather than assumed free — ⌃⌘N and ⌥⌘F,
        // the obvious choices, are already New Window and Focus Mode, and `ShortcutRegistryTests`
        // caught both the moment they were written.
        case .newEvent: KeyBinding("e", [.command, .control])
        case .searchCalendar: KeyBinding("f", [.command, .control])
        case .switchCalendarSet: KeyBinding("s", [.command, .option])

        // ⌃⌘Space for capture from anywhere, which is the one shortcut a task manager has to have
        // and the one place a global binding is worth the cost. See ADR 0008.
        case .quickTaskEntry: KeyBinding(" ", [.command, .control])
        case .goTasks: KeyBinding("7")
        // Return-adjacent, because completing is what you do most and ⌘Return is free here: the
        // lists are not text fields, and the text fields that exist handle their own Return.
        case .completeTask: KeyBinding("\r", .command)
        case .flagTask: KeyBinding("f", [.command, .shift])
        case .moveToToday: KeyBinding("t", [.command, .shift])
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
