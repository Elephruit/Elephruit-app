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
            ElephruitCommands(services: environment.services)
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
                TimerMenuBarContent(services: services) { environment.quickJot?.show() }
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

        // The calendar's menu bar item.
        //
        // A second extra rather than a section inside the timer's, because the two answer different
        // questions and are wanted at different moments: the timer is about what you are doing now,
        // and this is about what is next. Merging them would mean a label that has to choose which
        // to show, and it would be wrong half the time.
        MenuBarExtra {
            if case .ready(let services) = environment.state {
                CalendarMenuBarContent(
                    services: services,
                    onOpenCalendar: { environment.openCalendar() },
                    onQuickEntry: { environment.openCalendarQuickEntry() }
                )
            } else {
                Text("Opening your library…")
            }
        } label: {
            if case .ready(let services) = environment.state {
                CalendarMenuBarLabel(services: services)
            } else {
                Label("Calendar", systemImage: "calendar")
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
                RootView(
                    pendingCalendarRequest: environment.pendingCalendarRequest,
                    onCalendarRequestHandled: { environment.clearCalendarRequest() }
                )
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
            // Anything an intent left behind while the app was not running, or not frontmost.
            environment.adoptIntentRouting()

            // Development-only review overrides. Both are no-ops unless the matching argument was
            // passed alongside `-ElephruitDevelopmentMode`; see ``DesignReviewLaunch``.
            DesignReviewLaunch.applyAppearance()
            DesignReviewLaunch.applyWindowSize(
                to: NSApplication.shared.windows.first { $0.canBecomeMain && $0.isVisible }
            )
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
    @FocusedValue(\.rowActions) private var rowActions

    /// The services, for the few commands that act on the app rather than on a window.
    ///
    /// Switching Calendar Set is one: which calendars are showing is a property of the app's
    /// calendar rather than of a particular window, and two windows showing two different sets would
    /// be two answers to a question with one.
    let services: AppServices?

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

            Button("Quick Jot…") { navigation?.isQuickCaptureVisible = true }
                .shortcut(.quickCapture, in: shortcuts)

            Button("New Event…") {
                navigation?.select(.calendar)
                navigation?.isCalendarQuickEntryVisible = true
            }
            .shortcut(.newEvent, in: shortcuts)
            .disabled(navigation == nil)

            Button("Quick Task…") { navigation?.isTaskEntryVisible = true }
                .shortcut(.quickTaskEntry, in: shortcuts)

            // The same panel the global shortcut opens, rather than a second in-window route to the
            // same act. Quick Jot has two doors because a sheet is genuinely better than a floating
            // panel when the app is already in front of you; a timer has no such asymmetry — it is
            // one window, one clock, and the Time module already holds the full version of it.
            Button("Quick Log…") { services?.quickLog.show() }
                .shortcut(.quickLog, in: shortcuts)
                .disabled(services == nil)

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
                .shortcut(.importFiles, in: shortcuts)
                .disabled(transfer == nil)

            Button("Export Library…") { transfer?.export() }
                .shortcut(.exportLibrary, in: shortcuts)
                .disabled(transfer == nil)
        }

        // MARK: Edit

        CommandGroup(after: .pasteboard) {
            Divider()

            // Disabled from milestone one, which meant ⌘⌫ was printed in a menu and did nothing
            // in lists where ⌫ already worked. Each middle column publishes what deleting means
            // there, and this calls it.
            Button("Move to Trash") { rowActions?.moveToTrash() }
                .shortcut(.moveToTrash, in: shortcuts)
                .disabled(rowActions?.isEnabled != true)
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

            Button("Search Calendar") {
                navigation?.select(.calendar)
                navigation?.isCalendarSearchVisible = true
            }
            .shortcut(.searchCalendar, in: shortcuts)
            .disabled(navigation == nil)
        }

        // MARK: View

        CommandGroup(after: .sidebar) {
            Divider()

            // A keyboard way in and out, because the buttons themselves are revealed on hover and a
            // control you can only reach with a pointer is one a keyboard user cannot reach at all.
            if services?.miniTimer.isCollapsed == true {
                Button("Back to Elephruit") { services?.miniTimer.expand() }
                    .keyboardShortcut(KeyEquivalent("m"), modifiers: [.command, .control])
            } else {
                Button("Collapse to Timer") { services?.miniTimer.collapse() }
                    .keyboardShortcut(KeyEquivalent("m"), modifiers: [.command, .control])
                    .disabled(services == nil)
            }

            Divider()

            Button("Back") { navigation?.goBack() }
                .keyboardShortcut(KeyEquivalent("["), modifiers: .command)
                .disabled(navigation?.canGoBack != true)

            Button("Forward") { navigation?.goForward() }
                .keyboardShortcut(KeyEquivalent("]"), modifiers: .command)
                .disabled(navigation?.canGoForward != true)

            Divider()

            // The two destinations that belong to no module, in sidebar order. Both go through the
            // registry — nothing here is allowed to bind keys behind its back, because a binding
            // whose name and effect disagree is worse than no binding, and `ShortcutRegistry` gives
            // every shortcut exactly one owner so that a collision fails a test rather than
            // silently shadowing another menu item.
            Button("Today") { navigation?.select(.today) }
                .shortcut(.goToday, in: shortcuts)
            Button("Inbox") { navigation?.select(.inbox) }
                .shortcut(.goInbox, in: shortcuts)

            // Projects is not a module — the tree lives at the top level of the sidebar — so its
            // shortcut lives here with the other top-level destinations rather than in the Module
            // menu below, whose loop iterates `displayOrder` and rightly never sees it.
            Button("All Projects") { navigation?.select(.kind(.project)) }
                .shortcut(.goProjects, in: shortcuts)

            Divider()

            // Every module, in the order the sidebar lists them. This is the keyboard route into a
            // module: the module rows themselves are buttons rather than selectable list rows, so
            // that arrowing through the sidebar cannot enter one by accident.
            Menu("Module") {
                ForEach(AppModule.displayOrder) { module in
                    moduleButton(module)
                }

                Divider()

                Button("Back to All Modules") { navigation?.leaveModule() }
                    .disabled(navigation?.activeModule == nil)
            }

            Divider()

            Button("Next Calendar Set") {
                guard let calendar = services?.calendar else { return }
                let next = calendar.setAfterActive()
                Task { await calendar.activate(setID: next?.id) }
            }
            .shortcut(.switchCalendarSet, in: shortcuts)
            .disabled(services == nil)

            Divider()

            // Inside Tasks, where these are the module's own destinations rather than global ones.
            Button("Task Inbox") { navigation?.select(.taskView(.inbox)) }
            Button("Anytime") { navigation?.select(.taskView(.anytime)) }
                .shortcut(.goTasks, in: shortcuts)
            Button("Someday") { navigation?.select(.taskView(.someday)) }
            Button("Waiting") { navigation?.select(.taskView(.waiting)) }
            Button("Logbook") { navigation?.select(.taskView(.completed)) }

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

    /// One module's menu item, carrying the named shortcut where the registry has one for it.
    ///
    /// Only four modules have a binding of their own, and inventing six more would be inventing six
    /// claims on keys the user may already have spent. The rest are reachable by name here, in the
    /// palette, and by clicking.
    @ViewBuilder
    private func moduleButton(_ module: AppModule) -> some View {
        let command: ShortcutCommand? = switch module {
        case .calendar: .goCalendar
        case .notes: .goNotes
        case .records: .goPeople
        default: nil
        }

        Button {
            navigation?.enterModule(module)
        } label: {
            Label(module.title, systemImage: module.symbolName)
        }
        .shortcut(command, in: shortcuts)
        .disabled(navigation == nil)
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
///
/// ### Why this is a source list rather than five tabs across the top
/// Because it stopped being five. A row of tabs is the right shape while every one of them fits on
/// one line and each holds a handful of switches; past that the labels shorten until they stop
/// saying what is behind them, and a setting somebody is hunting for is behind whichever one they
/// have not tried yet. A list down the side names all nine at their full length, holds any number
/// more, and is what every settings window on this system has looked like since Ventura.
///
/// The reorganisation is not only cosmetic. Keyboard shortcuts were a section *inside* General's
/// Calendar group, which is not somewhere anybody would think to look for them; they now have their
/// own place. Everything time tracking can be told is in one place rather than scattered between a
/// toolbar, a menu, and nowhere.
struct SettingsView: View {
    let environment: AppEnvironment

    @AppStorage("confirmBeforeEmptyingTrash") private var confirmBeforeEmptyingTrash = true
    @AppStorage("people.showsFollowUps") private var showsFollowUpSuggestions = false
    @AppStorage("people.followUpThresholdDays") private var followUpThresholdDays = 0

    @State private var indexStatistics: (items: Int, terms: Int, isWarm: Bool)?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                general.accessibilityIdentifier(AccessibilityID.Settings.generalTab)
            }

            Tab("Appearance", systemImage: "paintpalette") {
                Form { AppearanceSettingsSection() }
                    .formStyle(.grouped)
                    .accessibilityIdentifier(AccessibilityID.Settings.editorTab)
            }

            Tab("Time", systemImage: "timer") {
                whenReady { services in
                    TimeSettingsSection().appServices(services)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.timeTab)
            }

            Tab("Tasks", systemImage: "checkmark.circle") {
                whenReady { services in
                    RemindersSettingsSection().appServices(services)
                }
                .accessibilityIdentifier("settings.tasks")
            }

            Tab("Calendar", systemImage: "calendar") {
                whenReady { services in
                    CalendarPreferencesSection(services: services)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.calendarTab)
            }

            Tab("Records", systemImage: "circle.grid.2x2") {
                people.accessibilityIdentifier(AccessibilityID.People.contactsSettings)
            }

            Tab("Shortcuts", systemImage: "keyboard") {
                whenReady { services in
                    ShortcutSettingsSection(
                        registry: services.shortcuts,
                        globalResults: environment.hotKeyResults
                    )
                }
                .accessibilityIdentifier(AccessibilityID.Settings.shortcutsTab)
            }

            Tab("Privacy", systemImage: "lock.shield") {
                privacy.accessibilityIdentifier(AccessibilityID.Settings.privacyTab)
            }

            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                advanced.accessibilityIdentifier(AccessibilityID.Settings.advancedTab)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(width: 720, height: 520)
        .accessibilityIdentifier(AccessibilityID.Settings.root)
    }

    /// A form whose contents need the library, and which says so plainly when it is not open yet.
    ///
    /// One helper rather than the same `if case .ready` at six call sites — which is where a tab
    /// added later quietly crashes a window opened during a migration.
    @ViewBuilder
    private func whenReady<Content: View>(
        @ViewBuilder _ content: @escaping (AppServices) -> Content
    ) -> some View {
        Form {
            if case .ready(let services) = environment.state {
                content(services)
            } else {
                Text("Available once your library is open.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
        .formStyle(.grouped)
    }

    /// Managing the address book connection.
    ///
    /// Its own tab rather than a section under General, because it is the one integration with an
    /// ongoing state — linked counts, a last-refresh time, conflicts awaiting a decision — and burying
    /// that under a Trash preference would make it undiscoverable at exactly the moment somebody goes
    /// looking for why a phone number is out of date.
    private var people: some View {
        Form {
            if case .ready(let services) = environment.state {
                ContactsSettingsSection()
                    .appServices(services)

                Section {
                    Toggle("Suggest people to follow up with", isOn: $showsFollowUpSuggestions)

                    if showsFollowUpSuggestions {
                        Stepper(
                            "After \(effectiveFollowUpDays) days without contact",
                            value: followUpThresholdBinding,
                            in: 7...365,
                            step: 7
                        )
                    }
                } header: {
                    Text("Follow-ups")
                } footer: {
                    Text("Off by default. An app that starts telling you who you have neglected, unprompted, is a different and worse product than one that answers when asked.")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Available once your library is open.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
        .formStyle(.grouped)
    }

    private var effectiveFollowUpDays: Int {
        followUpThresholdDays > 0 ? followUpThresholdDays : FollowUpPolicy.defaultThresholdDays
    }

    private var followUpThresholdBinding: Binding<Int> {
        Binding(get: { effectiveFollowUpDays }, set: { followUpThresholdDays = $0 })
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
        }
        .formStyle(.grouped)
    }

    /// What the app does and does not do with anything it can reach.
    ///
    /// Its own tab rather than a paragraph at the bottom of General. It is the claim this whole app
    /// is built around, it is the thing somebody checks before trusting it with a decade of notes,
    /// and a promise buried under a Trash preference reads like one somebody hoped nobody would find.
    private var privacy: some View {
        Form {
            Section {
                Label("This app makes no network requests.", systemImage: "lock.shield")

                Text("Your library is stored only on this Mac. There is no analytics, no telemetry, and no crash reporting. iCloud sync is not enabled in this version.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("What each integration may do") {
                PrivacyRow(
                    symbolName: "person.2",
                    title: "Contacts",
                    detail: "Read only. Your notes, reflections, and relationship history are never put into a contact."
                )
                PrivacyRow(
                    symbolName: "calendar",
                    title: "Calendar",
                    detail: "Reads your events, and writes only the events you ask it to — including tracked time, if you turn that on. What you record *about* a meeting stays here."
                )
                PrivacyRow(
                    symbolName: "checklist",
                    title: "Reminders",
                    detail: "Reads and writes the lists you tick. Areas, projects, Today, waiting-for, linked people, and provenance never cross."
                )
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
        guard let search = environment.services?.search else { return }
        indexStatistics = await search.indexStatistics()
    }

    private func revealLibrary() {
        guard let location = try? StoreLocation.application() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([location.root])
    }
}

/// One integration, and the shape of what it may do.
///
/// A row rather than a paragraph, because the question people arrive with is *which* of these
/// touches my data and in which direction — and three sentences of prose answers that only for
/// somebody who reads all three.
private struct PrivacyRow: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: symbolName)
                .frame(width: Theme.Size.rowGlyph)
                .foregroundStyle(Theme.Colors.secondaryText)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Text.rowTitleEmphasised)

                Text(detail)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
