import AppKit
import ElephruitCore
import ElephruitDesign
import ElephruitFeatures
import ElephruitModel
import ElephruitPersistence
import ElephruitSearch
import SwiftUI

/// The application.
///
/// Deliberately thin: it opens the store, puts the services in the environment, declares the scenes,
/// and wires the menu bar. Every behaviour lives in a module — see `docs/02-architecture.md`.
@main
struct ElephruitApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup("Elephruit", id: "main") {
            RootWindow(environment: environment)
        }
        .defaultSize(width: 1180, height: 760)
        // Restoring per-window layout is scene state, which SwiftUI persists for us; the library
        // itself is never restored from here.
        .windowToolbarStyle(.unified)
        .commands {
            ElephruitCommands()
        }

        Settings {
            SettingsView(environment: environment)
        }
    }
}

/// One window's contents, including the states before the library is available.
private struct RootWindow: View {
    let environment: AppEnvironment

    var body: some View {
        Group {
            switch environment.state {
            case .opening:
                // Deliberately quiet. Opening a local store takes milliseconds; a prominent spinner
                // would flash and draw the eye for no reason.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.windowBackground)
                    .accessibilityLabel("Opening your library")

            case .ready(let services):
                RootView()
                    .appServices(services)
                    .environment(\.prefersMonospacedEditor, prefersMonospacedEditor)

            case .failed(let error):
                FailureStateView(error: error) { option in
                    handleRecovery(option, error: error)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .task {
            if case .opening = environment.state {
                environment.start()
            }
        }
    }

    /// A lightweight preference, so `@AppStorage` is the right home — see the storage matrix.
    @AppStorage("prefersMonospacedEditor") private var prefersMonospacedEditor = false

    private func handleRecovery(_ option: RecoveryOption, error: AppError) {
        switch option {
        case .retry:
            environment.start()

        case .revealLibraryInFinder:
            if let location = try? StoreLocation.application() {
                NSWorkspace.shared.activateFileViewerSelecting([location.root])
            }

        case .revealBackupInFinder:
            if let location = try? StoreLocation.application() {
                NSWorkspace.shared.activateFileViewerSelecting([location.backupsRoot])
            }

        case .quit:
            NSApplication.shared.terminate(nil)

        default:
            break
        }
    }
}

// MARK: - Menu bar

/// The menu bar.
///
/// Every command here is a real menu item with a real shortcut, because that is how a Mac app is
/// discoverable and how the shortcuts show up in Help. The command palette offers the same actions;
/// neither is the only route to anything.
///
/// Commands act on the *focused* window through `@FocusedValue`, so a shortcut in one window never
/// moves another.
struct ElephruitCommands: Commands {
    @FocusedValue(\.navigationModel) private var navigation
    @FocusedValue(\.transferActions) private var transfer

    var body: some Commands {
        // MARK: File

        CommandGroup(replacing: .newItem) {
            Button("New Note") { create(.note) }
                .keyboardShortcut("n")

            Button("New Task") { create(.task) }
                .keyboardShortcut("n", modifiers: [.command, .option])

            Button("New Project") { create(.project) }
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])

            Divider()

            Button("Quick Capture…") { navigation?.isQuickCaptureVisible = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            // A new window is genuinely useful in this app — two projects side by side — so it is a
            // first-class command rather than something the user has to discover.
            Button("New Window") {
                if let url = URL(string: "everything://main") {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .control])
            .disabled(true)  // Enabled with the URL scheme in Phase 2.
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button("Import Files…") { transfer?.importFiles() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(transfer == nil)

            Button("Export Library…") { transfer?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(transfer == nil)
        }

        // MARK: Edit

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Move to Trash") { /* Handled per-list in Phase 2's multi-select work. */ }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(true)
        }

        // MARK: Find

        CommandGroup(replacing: .textEditing) {
            Button("Search Everything…") { navigation?.isSearchVisible = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(navigation == nil)

            Button("Command Palette…") { navigation?.isCommandPaletteVisible = true }
                .keyboardShortcut("k")
                .disabled(navigation == nil)
        }

        // MARK: View

        CommandGroup(after: .sidebar) {
            Divider()

            Button("Today") { navigation?.select(.today) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Inbox") { navigation?.select(.inbox) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Notes") { navigation?.select(.kind(.note)) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Tasks") { navigation?.select(.kind(.task)) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Projects") { navigation?.select(.kind(.project)) }
                .keyboardShortcut("4", modifiers: .command)
            Button("Areas") { navigation?.select(.kind(.area)) }
                .keyboardShortcut("5", modifiers: .command)

            Divider()

            Button("Upcoming") { navigation?.select(.upcoming) }
            Button("Trash") { navigation?.select(.trash) }

            Divider()

            Button("Toggle Inspector") { navigation?.isInspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(navigation == nil)
        }

        // MARK: Help

        CommandGroup(replacing: .help) {
            Link(
                "Elephruit Design Notes",
                destination: URL(filePath: FileManager.default.currentDirectoryPath)
                    .appending(path: "docs", directoryHint: .isDirectory)
            )
            .disabled(true)  // Bundled documentation arrives with the App Store build.
        }
    }

    private func create(_ kind: ItemKind) {
        guard let navigation else { return }
        navigation.select(.kind(kind))
        // The list's own new-item action creates in context; this puts the user where it will land.
        navigation.isQuickCaptureVisible = false
    }
}

// MARK: - Settings

/// Preferences.
///
/// Only genuine preferences live here. Anything that is user *content* belongs in the library, and
/// anything derived belongs in a cache — see `docs/03-storage-matrix.md`.
struct SettingsView: View {
    let environment: AppEnvironment

    @AppStorage("prefersMonospacedEditor") private var prefersMonospacedEditor = false
    @AppStorage("confirmBeforeEmptyingTrash") private var confirmBeforeEmptyingTrash = true

    @State private var indexStatistics: (items: Int, terms: Int, isWarm: Bool)?

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .accessibilityIdentifier(AccessibilityID.Settings.generalTab)

            editor
                .tabItem { Label("Editor", systemImage: "textformat") }
                .accessibilityIdentifier(AccessibilityID.Settings.editorTab)

            advanced
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .accessibilityIdentifier(AccessibilityID.Settings.advancedTab)
        }
        .frame(width: 460, height: 300)
        .accessibilityIdentifier(AccessibilityID.Settings.root)
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Ask before emptying the Trash", isOn: $confirmBeforeEmptyingTrash)
            } footer: {
                Text("Emptying the Trash cannot be undone.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Section("Privacy") {
                Label("This app makes no network requests.", systemImage: "lock.shield")
                Text("Your library is stored only on this Mac. There is no analytics, no telemetry, and no crash reporting. iCloud sync is not enabled in this version.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var editor: some View {
        Form {
            Toggle("Use a monospaced font", isOn: $prefersMonospacedEditor)

            Section {
                Text("Note bodies are stored as plain, Markdown-compatible text. Formatting is never written into your notes, so they remain readable in any text editor.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            // A string title and a footer are not combinable in one `Section` initialiser, so the
            // header is spelled out.
            Section {
                if let statistics = indexStatistics {
                    LabeledContent("Indexed items", value: "\(statistics.items)")
                    LabeledContent("Distinct terms", value: "\(statistics.terms)")
                    LabeledContent("State", value: statistics.isWarm ? "Ready" : "Building")
                }

                Button("Rebuild Search Index") { rebuildIndex() }
                    .accessibilityIdentifier(AccessibilityID.Settings.rebuildIndexButton)
            } header: {
                Text("Search Index")
            } footer: {
                Text("The index is a cache built from your library. Rebuilding it cannot lose data.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Section("Library") {
                LabeledContent("Schema version", value: schemaVersion)
                Button("Reveal Library in Finder") { revealLibrary() }
            }

            if environment.services?.isDevelopmentMode == true {
                Section("Development") {
                    Button("Load Sample Data") { environment.services?.loadSampleData() }
                    Text("Only available in development mode.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshStatistics() }
    }

    private var schemaVersion: String {
        CurrentSchema.versionString
    }

    private func rebuildIndex() {
        guard let services = environment.services else { return }
        Task {
            await services.search.invalidateIndex()
            await services.warmSearchIndex()
            await refreshStatistics()
        }
    }

    private func refreshStatistics() async {
        guard let engine = environment.services?.search as? DefaultSearchEngine else { return }
        indexStatistics = await engine.indexStatistics()
    }

    private func revealLibrary() {
        guard let location = try? StoreLocation.application() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([location.root])
    }
}
