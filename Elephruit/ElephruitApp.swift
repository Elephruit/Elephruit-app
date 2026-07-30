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

        // The menu bar timer.
        //
        // A timer runs while you are doing something *else*, usually in another app. One you can
        // only see by switching to Elephruit is one you forget is running, and a forgotten timer is
        // how eleven hours end up billed to a task that took two.
        //
        // `.window` style rather than `.menu` so the elapsed time can be a live label rather than a
        // static icon.
        MenuBarExtra {
            if case .ready(let services) = environment.state {
                TimerMenuBarContent(services: services)
            } else {
                Text("Opening your library…")
            }
        } label: {
            if case .ready(let services) = environment.state {
                TimerMenuBarLabel(services: services)
            } else {
                Label("Elephruit", systemImage: "timer")
            }
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

    /// The bindings, from the one place that decides them.
    ///
    /// Read from preferences rather than held, because `Commands` is a value rebuilt on change and
    /// has no services in its environment. The registry is small and the read is rare — a menu is
    /// not rebuilt on a keystroke.
    private var shortcuts: ShortcutRegistry { ShortcutRegistry.load(from: .standard) }

    var body: some Commands {
        // MARK: File

        CommandGroup(replacing: .newItem) {
            Button("New Note") { create(.note) }
                .shortcut(.newItem, in: shortcuts)

            Button("New Task") { create(.task) }
                .shortcut(.newTask, in: shortcuts)

            Button("New Project") { create(.project) }
                .shortcut(.newProject, in: shortcuts)

            Divider()

            Button("Quick Capture…") { navigation?.isQuickCaptureVisible = true }
                .shortcut(.quickCapture, in: shortcuts)

            Divider()

            // A new window is genuinely useful in this app — two projects side by side — so it is a
            // first-class command rather than something the user has to discover.
            Button("New Window") {
                if let url = URL(string: "everything://main") {
                    NSWorkspace.shared.open(url)
                }
            }
            .shortcut(.newWindow, in: shortcuts)
            .disabled(true)  // Enabled with the URL scheme in Phase 2.
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button("Import Files…") { transfer?.importFiles() }
                .shortcut(.toggleInspector, in: shortcuts)
                .disabled(transfer == nil)

            Button("Export Library…") { transfer?.export() }
                .shortcut(.exportLibrary, in: shortcuts)
                .disabled(transfer == nil)
        }

        // MARK: Edit

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Move to Trash") { /* Handled per-list in Phase 2's multi-select work. */ }
                .shortcut(.moveToTrash, in: shortcuts)
                .disabled(true)
        }

        // MARK: Find

        CommandGroup(replacing: .textEditing) {
            // ⌘F, not ⌘⇧F. Search is no longer a separate place with its own shortcut — it is what
            // the list becomes — so it takes the shortcut everyone already reaches for.
            Button("Search Everything") { navigation?.beginSearch() }
                .shortcut(.search, in: shortcuts)
                .disabled(navigation == nil)

            Button("Command Palette…") { navigation?.isCommandPaletteVisible = true }
                .shortcut(.commandPalette, in: shortcuts)
                .disabled(navigation == nil)
        }

        // MARK: View

        CommandGroup(after: .sidebar) {
            Divider()

            Button("Today") { navigation?.select(.today) }
                .shortcut(.goToday, in: shortcuts)
            Button("Inbox") { navigation?.select(.inbox) }
                .shortcut(.goInbox, in: shortcuts)
            Button("Notes") { navigation?.select(.kind(.note)) }
                .shortcut(.goUpcoming, in: shortcuts)
            Button("Tasks") { navigation?.select(.kind(.task)) }
                .shortcut(.goNotes, in: shortcuts)
            Button("Projects") { navigation?.select(.kind(.project)) }
                .shortcut(.goProjects, in: shortcuts)
            Button("Areas") { navigation?.select(.kind(.area)) }
                .shortcut(.goPeople, in: shortcuts)

            Divider()

            Button("Upcoming") { navigation?.select(.upcoming) }
            Button("Trash") { navigation?.select(.trash) }

            Divider()

            Button("Toggle Sidebar") { navigation?.toggleSidebar() }
                .shortcut(.toggleSidebar, in: shortcuts)
                .disabled(navigation == nil)

            Button("Toggle Inspector") { navigation?.isInspectorVisible.toggle() }
                .shortcut(.toggleInspectorAlternate, in: shortcuts)
                .disabled(navigation == nil)

            Button(navigation?.layoutMode == .focus ? "Leave Focus Mode" : "Focus Mode") {
                navigation?.toggleFocusMode()
            }
            .shortcut(.focusMode, in: shortcuts)
            .disabled(navigation == nil)

            Divider()

            Button("Focus Sidebar") { navigation?.focus(.sidebar) }
                .shortcut(.clearSelection, in: shortcuts)
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

            Section("Calendar") {
                if case .ready(let services) = environment.state {
                    CalendarSettingsSection(calendar: services.calendar)
                } else {
                    Text("Available once your library is open.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            Section("Privacy") {
                Label("This app makes no network requests.", systemImage: "lock.shield")
                Text("Your library is stored only on this Mac. There is no analytics, no telemetry, and no crash reporting. iCloud sync is not enabled in this version. If you turn on Calendar, Elephruit reads your events and never writes to them.")
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
