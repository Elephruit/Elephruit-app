import ElephruitCore
import Foundation
import Testing

/// One owner per binding, and a conflict the user can see.
///
/// Before the registry there were forty `.keyboardShortcut` literals scattered across the app, and
/// the command palette carried a *second* description of some of them as glyph arrays — two
/// representations of the same fact with nothing keeping them equal. A palette that shows ⌘⇧N for a
/// command bound to something else is worse than one that shows nothing.
@Suite("Shortcut registry")
struct ShortcutRegistryTests {
    @Test("Nothing ships with two commands on the same keys")
    func defaultsDoNotCollide() {
        let registry = ShortcutRegistry()
        #expect(registry.collisions.isEmpty, "\(registry.collisions.map(\.explanation))")
    }

    @Test("Every command has a title and a default binding")
    func everyCommandIsComplete() {
        for command in ShortcutCommand.allCases {
            #expect(!command.title.isEmpty)
            #expect(!command.defaultBinding.key.isEmpty)
        }
    }

    @Test("A binding resolves back to exactly one command")
    func bindingsAreOwned() throws {
        let registry = ShortcutRegistry()
        let quickCapture = try #require(registry.binding(for: .quickCapture))
        #expect(registry.command(for: quickCapture) == .quickCapture)
    }

    // MARK: - Overrides

    @Test("An override replaces the default")
    func overridesApply() {
        var registry = ShortcutRegistry()
        registry.setBinding(KeyBinding("j", [.command, .shift]), for: .quickCapture)

        #expect(registry.binding(for: .quickCapture) == KeyBinding("j", [.command, .shift]))
        #expect(registry.binding(for: .search) == ShortcutCommand.search.defaultBinding)
    }

    /// Unbound and untouched are different states. A command the user deliberately cleared must not
    /// quietly come back on the next launch.
    @Test("A command can be deliberately unbound, which is not the same as untouched")
    func unbindingIsDistinctFromDefault() {
        var registry = ShortcutRegistry()
        registry.setBinding(nil, for: .focusMode)

        #expect(registry.binding(for: .focusMode) == nil)
        #expect(ShortcutCommand.focusMode.defaultBinding.key == "f")
    }

    @Test("Setting a command back to its default stops it being an override")
    func settingTheDefaultClearsTheOverride() {
        var registry = ShortcutRegistry()
        registry.setBinding(KeyBinding("j", [.command, .shift]), for: .quickCapture)
        registry.setBinding(ShortcutCommand.quickCapture.defaultBinding, for: .quickCapture)

        #expect(registry.overrides.isEmpty)
    }

    @Test("Resetting restores the default")
    func resetting() {
        var registry = ShortcutRegistry()
        registry.setBinding(nil, for: .search)
        registry.reset(.search)
        #expect(registry.binding(for: .search) == ShortcutCommand.search.defaultBinding)

        registry.setBinding(KeyBinding("q"), for: .search)
        registry.resetAll()
        #expect(registry.overrides.isEmpty)
    }

    // MARK: - Collisions

    /// Reported, not refused. Refusing would mean two shortcuts cannot be swapped without an
    /// impossible intermediate state; dropping one silently would be worse than either.
    @Test("A collision is reported rather than prevented")
    func collisionsAreReported() throws {
        var registry = ShortcutRegistry()
        registry.setBinding(ShortcutCommand.search.defaultBinding, for: .commandPalette)

        let collision = try #require(registry.collisions.first)
        #expect(collision.commands.contains(.search))
        #expect(collision.commands.contains(.commandPalette))
        #expect(collision.explanation.contains("⌘F"))

        // Both keep their binding; neither was silently dropped.
        #expect(registry.binding(for: .search) != nil)
        #expect(registry.binding(for: .commandPalette) != nil)
        // And an ambiguous binding has no single owner.
        #expect(registry.command(for: ShortcutCommand.search.defaultBinding) == nil)
    }

    @Test("Unbinding one side clears the collision")
    func unbindingResolvesACollision() {
        var registry = ShortcutRegistry()
        registry.setBinding(ShortcutCommand.search.defaultBinding, for: .commandPalette)
        #expect(!registry.collisions.isEmpty)

        registry.setBinding(nil, for: .commandPalette)
        #expect(registry.collisions.isEmpty)
    }

    // MARK: - Glyphs

    @Test("Glyphs read in the order macOS writes them")
    func glyphOrder() {
        #expect(KeyBinding("n", [.command, .shift]).glyphs == ["⇧", "⌘", "N"])
        #expect(KeyBinding("t", [.command, .control]).glyphs == ["⌃", "⌘", "T"])
        #expect(KeyBinding("f", [.command, .option]).glyphs == ["⌥", "⌘", "F"])
        #expect(KeyBinding("n", [.command, .shift, .option]).glyphs == ["⌥", "⇧", "⌘", "N"])
    }

    @Test("Case is carried by shift, not by the letter")
    func keysAreNormalised() {
        #expect(KeyBinding("N").key == "n")
        #expect(KeyBinding("N") == KeyBinding("n"))
    }

    // MARK: - Persistence

    @Test("Overrides survive a round trip through preferences")
    func persistence() throws {
        let defaults = try #require(UserDefaults(suiteName: "ShortcutRegistryTests-\(UUID().uuidString)"))
        defer { defaults.removeSuite(named: defaults.description) }

        var registry = ShortcutRegistry()
        registry.setBinding(KeyBinding("j", [.command, .shift]), for: .quickCapture)
        registry.setBinding(nil, for: .focusMode)
        registry.save(to: defaults)

        let loaded = ShortcutRegistry.load(from: defaults)
        #expect(loaded.binding(for: .quickCapture) == KeyBinding("j", [.command, .shift]))
        #expect(loaded.binding(for: .focusMode) == nil, "a deliberate unbinding came back")
        #expect(loaded.binding(for: .search) == ShortcutCommand.search.defaultBinding)
    }

    @Test("Clearing every override removes the stored value rather than writing an empty one")
    func emptyOverridesAreNotStored() throws {
        let defaults = try #require(UserDefaults(suiteName: "ShortcutRegistryTests-\(UUID().uuidString)"))
        defer { defaults.removeSuite(named: defaults.description) }

        var registry = ShortcutRegistry()
        registry.setBinding(KeyBinding("j"), for: .quickCapture)
        registry.save(to: defaults)
        registry.resetAll()
        registry.save(to: defaults)

        #expect(ShortcutRegistry.load(from: defaults).overrides.isEmpty)
    }

    /// A corrupt preference should cost the user their customisations, not their launch.
    @Test("Unreadable stored data falls back to the defaults")
    func corruptStorageDegrades() throws {
        let defaults = try #require(UserDefaults(suiteName: "ShortcutRegistryTests-\(UUID().uuidString)"))
        defer { defaults.removeSuite(named: defaults.description) }

        defaults.set(Data("not json".utf8), forKey: "shortcuts.overrides")

        let loaded = ShortcutRegistry.load(from: defaults)
        #expect(loaded.overrides.isEmpty)
        #expect(loaded.binding(for: .search) == ShortcutCommand.search.defaultBinding)
    }

    @Test("A stored command this build does not know is ignored, not fatal")
    func unknownCommandsAreIgnored() throws {
        let defaults = try #require(UserDefaults(suiteName: "ShortcutRegistryTests-\(UUID().uuidString)"))
        defer { defaults.removeSuite(named: defaults.description) }

        let json = #"{"someFutureCommand":{"key":"z","modifiers":1}}"#
        defaults.set(Data(json.utf8), forKey: "shortcuts.overrides")

        #expect(ShortcutRegistry.load(from: defaults).overrides.isEmpty)
    }
}
