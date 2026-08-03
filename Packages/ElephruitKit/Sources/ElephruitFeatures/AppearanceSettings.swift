import AppKit
import ElephruitDesign
import SwiftUI

/// Which appearance the app draws in, whatever the system is doing.
///
/// ### Why an override exists at all when the app already follows the system
/// Because "follow the system" is the right default and the wrong rule for the one case it cannot
/// serve: somebody whose Mac switches to dark at sunset and who wants *this* window to stay light
/// because they read long notes in it. Everything else — the palette, the selection colour, contrast
/// — still resolves through AppKit; this only decides which of its two answers is asked for.
public enum AppTheme: String, CaseIterable, Sendable, Codable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// The AppKit appearance to force, or `nil` to let the system decide.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Applies this to the running app.
    ///
    /// Setting `NSApp.appearance` rather than each window's, so a window opened later starts in the
    /// right one instead of flickering into it.
    @MainActor
    public func apply() {
        NSApp?.appearance = appearance
    }

    /// What settings last chose, for the launch that has not read it yet.
    @MainActor
    public static func restore(from defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: storageKey) ?? AppTheme.system.rawValue
        (AppTheme(rawValue: stored) ?? .system).apply()
    }

    public static let storageKey = "appearance.theme"
}

/// Appearance and editing preferences.
public struct AppearanceSettingsSection: View {
    @AppStorage(AppTheme.storageKey) private var storedTheme = AppTheme.system.rawValue
    @AppStorage("prefersMonospacedEditor") private var prefersMonospacedEditor = false

    public init() {}

    public var body: some View {
        Section {
            Picker("Appearance", selection: themeBinding) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Label(theme.displayName, systemImage: theme.symbolName).tag(theme)
                }
            }
            .pickerStyle(.inline)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Colors, selection, and contrast follow macOS either way — including your accent color and Increase Contrast. This only decides which appearance is asked for.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            Toggle("Use a monospaced font in the editor", isOn: $prefersMonospacedEditor)
        } footer: {
            Text("Note bodies are stored as plain, Markdown-compatible text. Formatting is never written into your notes, so they remain readable in any text editor.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { AppTheme(rawValue: storedTheme) ?? .system },
            set: { newValue in
                storedTheme = newValue.rawValue
                // Applied as it is chosen rather than on the next launch, because an appearance
                // picker that does nothing until you quit is one nobody believes worked.
                newValue.apply()
            }
        )
    }
}
